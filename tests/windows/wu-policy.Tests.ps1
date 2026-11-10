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
    $script:readFailAfterFix = $false
}
function Copy-Map { param($m) if ($null -eq $m) { return $null }; $c = [ordered]@{}; foreach ($k in $m.Keys) { $c[$k] = $m[$k] }; $c }
# readFailAfterFix: the AU key cannot be read once the fix has changed something.
function Get-WupState {
    $au = Copy-Map $script:reg[$WupAuKey]
    if ($script:readFailAfterFix -and $script:calls.Count -gt 0) { $au = @{ error = 'access denied' } }
    [ordered]@{ wu = (Copy-Map $script:reg[$WupKey]); au = $au; registryPol = (Copy-Map $script:pol); appraiserTask = 'Ready' }
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


# Registry.pol entries as the parser returns them.
$auK = 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU'
$wuK = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
function New-PolEntry { param($Key, $Name, $Data) [pscustomobject]@{ key = $Key; name = $Name; data = $Data } }
function New-Pol { param([int]$Other, [object[]]$Wu) [ordered]@{ exists = $true; size = 300; entries = ($Other + @($Wu).Count); other = $Other; wu = @($Wu) } }

# Check mode: blocked, but nothing is written.
$blockedAu = [ordered]@{ NoAutoUpdate = 1; AUOptions = 1; ScheduledInstallDay = 0 }
$blockedWu = [ordered]@{ DisableWindowsUpdateAccess = 1; SetDisableUXWUAccess = 1; DisableOSUpgrade = 1; DeferFeatureUpdatesPeriodInDays = 30; PauseFeatureUpdatesStartTime = '2025-01-01' }
Reset-Fake -Au (Copy-Map $blockedAu) -Wu (Copy-Map $blockedWu) -Pol (New-Pol 0 @((New-PolEntry $auK 'NoAutoUpdate' 1), (New-PolEntry $auK 'AUOptions' 1)))
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

# A policy key that cannot be read is a failure, not "no policy": before the
# fix it changes nothing, and after the fix it is not reported as fixed.
Reset-Fake -Au @{ error = 'access denied' } -Wu $null
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 1 'read error exit'
Assert-Same $run.record.verdict 'policy read failed, not changed: au access denied' 'read error verdict'
Assert-Same $script:calls.Count 0 'read error changes nothing'
Reset-Fake -Au (Copy-Map $blockedAu) -Wu $null
$script:readFailAfterFix = $true
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 1 'read error after fix exit'
Assert-Like $run.record.verdict 'fix not verified, policy read failed: au access denied*' 'read error after fix verdict'

# SetDisableUXWUAccess 0 and NoAutoUpdate 0 stay; AUOptions 3+ stays.
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 0; AUOptions = 4 }) -Wu ([ordered]@{ DisableWindowsUpdateAccess = 1; SetDisableUXWUAccess = 0 })
$null = Invoke-WupRun -Fix
Assert-Same (($script:calls | Where-Object { $_ -like 'remove *' }) -join ',') 'remove DisableWindowsUpdateAccess' 'only the blocking value'

# Registry.pol is renamed only when every entry re-applies a value this fix
# deletes: other policy, a non-blocking value, a value not being deleted, or a
# value under the wrong key keeps the file, because removing it can drop that policy.
function Get-RenamePlan { param($Pol) (Get-WupPlan ([ordered]@{ au = [ordered]@{ NoAutoUpdate = 1 }; wu = $null; registryPol = $Pol })).renamePol }
$noAuto = New-PolEntry $auK 'NoAutoUpdate' 1
Assert-Same (Get-RenamePlan (New-Pol 0 @($noAuto))) $true 'only fix entries: renamed'
Assert-Same (Get-RenamePlan (New-Pol 0 @($noAuto, (New-PolEntry $auK '**del.NoAutoUpdate' $null)))) $true 'del directive for a deleted value: renamed'
Assert-Same (Get-RenamePlan (New-Pol 9 @($noAuto))) $false 'fix value plus other policy: left'
Assert-Same (Get-RenamePlan (New-Pol 2 @())) $false 'small file of other policy: left'
Assert-Same (Get-RenamePlan (New-Pol 0 @((New-PolEntry $auK 'AUOptions' 4)))) $false 'AUOptions 4 in the file while live NoAutoUpdate is deleted: left'
Assert-Same (Get-RenamePlan (New-Pol 0 @($noAuto, (New-PolEntry $auK 'AUOptions' 1)))) $false 'blocking value not planned for delete: left'
Assert-Same (Get-RenamePlan (New-Pol 0 @((New-PolEntry $wuK 'NoAutoUpdate' 1)))) $false 'value under the wrong key: left'
Assert-Same (Get-RenamePlan (New-Pol 0 @())) $false 'empty file: left'
Assert-Same (Get-RenamePlan ([ordered]@{ exists = $true; size = 158; parseError = 'no ]' })) $false 'unparsed file: left'
Assert-Same (Test-WupFixEntry (New-PolEntry $auK 'AUOptions' 2) @('AUOptions')) $true 'AUOptions 2 is a fix entry'
Assert-Same (Test-WupFixEntry (New-PolEntry $wuK 'SetDisableUXWUAccess' 0) @('SetDisableUXWUAccess')) $false 'SetDisableUXWUAccess 0 is not'
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1 }) -Wu $null -Pol (New-Pol 9 @($noAuto))
$run = Invoke-WupRun -Fix
Assert-Same ($script:calls -contains 'rename') $false 'pol with other policy not renamed'
Assert-Like $run.record.verdict '*Registry.pol left (9 other entries)' 'pol left said'

# Verify after gpupdate: a value the policy puts back fails the run.
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1 }) -Wu $null -Pol (New-Pol 9 @($noAuto))
$script:gpRestores = $true
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 1 'value back after gpupdate exit'
Assert-Like $run.record.verdict 'fix incomplete: still set NoAutoUpdate*' 'value back after gpupdate verdict'

# Registry.pol parsing: PReg header, then [key;name;type;size;data] in UTF-16LE.
# Entries here are "key;name;dword".
function New-PolBytes {
    param([string[]]$Entries)
    $u = [Text.Encoding]::Unicode
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange([Text.Encoding]::ASCII.GetBytes('PReg')); $b.AddRange([BitConverter]::GetBytes([uint32]1))
    foreach ($e in $Entries) {
        $kv = $e -split ';', 3
        $b.AddRange($u.GetBytes("[$($kv[0])`0;$($kv[1])`0;"))
        $b.AddRange([BitConverter]::GetBytes([uint32]4)); $b.AddRange($u.GetBytes(';'))
        $b.AddRange([BitConverter]::GetBytes([uint32]4)); $b.AddRange($u.GetBytes(';'))
        $b.AddRange([BitConverter]::GetBytes([uint32]$kv[2])); $b.AddRange($u.GetBytes(']'))
    }
    return , $b.ToArray()
}
$bytes = New-PolBytes @("$auK;NoAutoUpdate;1", "$wuK;SetDisableUXWUAccess;0", 'Software\Policies\Microsoft\Edge;HomepageLocation;7')
Assert-Same ((Get-WupPolEntries $bytes | ForEach-Object { "$($_.key);$($_.name);$($_.data)" }) -join '|') "$auK;NoAutoUpdate;1|$wuK;SetDisableUXWUAccess;0|Software\Policies\Microsoft\Edge;HomepageLocation;7" 'pol entries'
Assert-Same @(Get-WupPolEntries (New-PolBytes @())).Count 0 'header-only pol'
$threw = $false
try { $null = Get-WupPolEntries $bytes[0..($bytes.Length - 3)] } catch { $threw = $true }
if (-not $threw) { Fail 'truncated pol parsed' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wup-" + [guid]::NewGuid() + '.pol')
[IO.File]::WriteAllBytes($tmp, $bytes)
$info = Get-WupPolInfo $tmp
[IO.File]::WriteAllBytes($tmp, $bytes[0..20])
$bad = Get-WupPolInfo $tmp
[IO.File]::Delete($tmp)
Assert-Same $info.size ([long]$bytes.Length) 'pol size'
Assert-Same $info.entries 3 'pol entry count'
Assert-Same $info.other 1 'pol other entries'
Assert-Same ((@($info.wu) | ForEach-Object { $_.name }) -join ',') 'NoAutoUpdate,SetDisableUXWUAccess' 'pol Windows Update entries'
if (-not $bad.Contains('parseError') -or $bad.Contains('other')) { Fail 'malformed pol not marked unparsed' }
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

# The pin record names no RMM field; the package arguments example decodes to what the script reads.
$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/wu-policy.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware'
if ($release.PSObject.Properties.Name -contains 'ninjaField') { Fail 'pin record names an RMM field; the package reports on stdout only' }
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
# Line endings normalized so a CRLF checkout passes too; a missing match fails.
$self = [IO.File]::ReadAllText($PSCommandPath) -replace "`r`n", "`n"
$firstExit = $self.IndexOf("exit 0`n", [StringComparison]::Ordinal)
if ($firstExit -lt 0 -or $firstExit -lt $self.IndexOf('Assert-Same $pairs[0].Value', [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'wu-policy tests passed'
exit 0
