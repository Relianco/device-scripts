$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/comet-vss-provider/Invoke-CometVssProvider.ps1')

function Assert($ok, $message) { if (-not $ok) { throw $message } }
function Same([string[]]$a, [string[]]$b) { ($a -join "`n") -ceq ($b -join "`n") -and $a.Count -eq $b.Count }

$line = 'COMET_FORCE_VSS_PROVIDER=system'

# Pure line transforms.
$kept = @('TEMP=Z:\Temp', 'TMP=Z:\Temp')
Assert (Same (Set-CvVssLine $kept) @('TEMP=Z:\Temp', 'TMP=Z:\Temp', $line)) 'Install appends after every other entry, order kept'
Assert (Same (Set-CvVssLine @('TEMP=Z:\Temp', $line, 'TMP=Z:\Temp')) @('TEMP=Z:\Temp', $line, 'TMP=Z:\Temp')) 'Compliant value unchanged in place'
Assert (Same (Set-CvVssLine @('A=1', ' comet_force_vss_provider = qemu', 'B=2', $line, 'COMET_FORCE_VSS_PROVIDER=system')) @('A=1', $line, 'B=2')) 'Variants and duplicates normalised to one line at the first position'
Assert (Same (Set-CvVssLine @()) @($line)) 'Empty value gets the line'
Assert (Same (Remove-CvVssLine @('TEMP=Z:\Temp', $line, 'COMET_FORCE_VSS_PROVIDER = System', 'TMP=Z:\Temp')) @('TEMP=Z:\Temp', 'TMP=Z:\Temp')) 'Uninstall removes only the VSS lines'
Assert (Test-CvCompliant @('TEMP=Z:\Temp', $line)) 'One exact line is compliant'
Assert (-not (Test-CvCompliant @($line, $line))) 'Duplicate line is not compliant'
Assert (-not (Test-CvCompliant @('COMET_FORCE_VSS_PROVIDER=System'))) 'Case variant is not compliant'

# Redaction.
Assert ((Protect-CvLine 'TEMP=Z:\Temp') -eq 'TEMP=Z:\Temp') 'Plain path shown'
# Fixture values are generated at run time so no credential-shaped literal is committed.
$secretName = 'S3_' + 'SECRET' + '_KEY'
$tokenValue = [guid]::NewGuid().ToString('n') + [guid]::NewGuid().ToString('n')
Assert ((Protect-CvLine ($secretName + '=' + 'v1')) -eq ($secretName + '=[redacted]')) 'Secret-named value redacted'
Assert ((Protect-CvLine ('HTTP_PROXY=http://u' + ':' + 'x@proxy.invalid')) -eq 'HTTP_PROXY=[redacted]') 'URL userinfo redacted'
Assert ((Protect-CvLine ('X=' + $tokenValue)) -eq 'X=[redacted]') 'Long token-shaped value redacted'
Assert ((Protect-CvLine $tokenValue) -eq '[redacted]') 'Token-shaped line without a name redacted'

# A fake device: registry, processes, services, marker.
function New-Fake {
    param([string[]]$Delegate, [string[]]$Elevator, [string]$Manufacturer = 'QEMU', [string[]]$CommandLines = @())
    $f = [pscustomobject]@{
        Values = @{ 'backup.delegate' = $Delegate; 'backup.elevator' = $Elevator }
        Kinds = @{ 'backup.delegate' = 'MultiString'; 'backup.elevator' = 'MultiString' }
        Writes = 0; Restarts = [System.Collections.Generic.List[string]]::new(); Marker = $false
        Manufacturer = $Manufacturer; CommandLines = $CommandLines
    }
    $script:Fake = $f
    $script:CvRead = { param($svc) [pscustomobject]@{ Exists = $true; Kind = $script:Fake.Kinds[$svc]; Lines = $script:Fake.Values[$svc] } }
    $script:CvWrite = { param($svc, [string[]]$lines) $script:Fake.Values[$svc] = $lines; $script:Fake.Writes++ }
    $script:CvComputer = { [pscustomobject]@{ Manufacturer = $script:Fake.Manufacturer; Model = 'Standard PC' } }
    $script:CvQemuAgent = { $false }
    $script:CvProviders = { @('Microsoft Software Shadow Copy provider 1.0') }
    $script:CvProcesses = { @($script:Fake.CommandLines | ForEach-Object { [pscustomobject]@{ Name = 'backup-tool.exe'; CommandLine = $_ } }) }
    $script:CvRestart = { param($svc) $script:Fake.Restarts.Add($svc) }
    $script:CvGetMarker = { $script:Fake.Marker }
    $script:CvSetMarker = { param([bool]$on) $script:Fake.Marker = $on }
    return $f
}
$idle = @('"C:\Program Files\Comet\backup-tool.exe" delegate-server', '"C:\Program Files\Comet\backup-tool.exe" elevator-server', '"C:\Program Files\Comet\backup-tool.exe" stream 12')

# Install preserves TEMP/TMP, restarts both once, and repeated runs stay at one line with no restart.
$f = New-Fake -Delegate @('TEMP=Z:\Temp', 'TMP=Z:\Temp') -Elevator @('TEMP=Z:\Temp', 'TMP=Z:\Temp') -CommandLines $idle
$r = Invoke-CvMain -Action Install
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'applied') "Install applies on idle QEMU guest: $($r.Result.Status)"
Assert (Same $f.Values['backup.delegate'] @('TEMP=Z:\Temp', 'TMP=Z:\Temp', $line)) 'Delegate keeps TEMP/TMP'
Assert (Same $f.Values['backup.elevator'] @('TEMP=Z:\Temp', 'TMP=Z:\Temp', $line)) 'Elevator keeps TEMP/TMP'
Assert (Same $f.Restarts @('backup.delegate', 'backup.elevator')) 'Both services restarted once'
for ($i = 0; $i -lt 3; $i++) { $r = Invoke-CvMain -Action Install }
Assert ($r.Result.Status -eq 'compliant' -and $f.Restarts.Count -eq 2 -and $f.Writes -eq 2) 'Repeated runs neither write nor restart'
Assert (@($f.Values['backup.delegate'] | Where-Object { $_ -eq $line }).Count -eq 1) 'Exactly one VSS line after repeated runs'

# Non-QEMU refused without force; forced with AllowNonQemu.
$f = New-Fake -Delegate @() -Elevator @() -Manufacturer 'Microsoft Corporation' -CommandLines $idle
$r = Invoke-CvMain -Action Install
Assert ($r.Result.Status -eq 'notQemuGuest' -and $f.Writes -eq 0 -and $f.Restarts.Count -eq 0) 'Non-QEMU refused'
$r = Invoke-CvMain -Action Install -AllowNonQemu 'true'
Assert ($r.Result.Status -eq 'applied' -and $f.Writes -eq 2) 'Force applies on non-QEMU'
$f = New-Fake -Delegate @() -Elevator @() -Manufacturer 'Microsoft Corporation' -CommandLines $idle
$script:CvQemuAgent = { $true }
Assert ((Invoke-CvMain -Action Install).Result.Status -eq 'applied') 'Registered QEMU guest agent counts as a QEMU guest'

# A running job: value set, restart skipped, pending; a later idle run restarts once.
$job = $idle + @('"C:\Program Files\Comet\backup-tool.exe" backup --rule 1234')
$f = New-Fake -Delegate @('TEMP=Z:\Temp') -Elevator @('TEMP=Z:\Temp') -CommandLines $job
$r = Invoke-CvMain -Action Install
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'restartPending' -and $r.Result.RestartPending) 'Running job reports restartPending'
Assert ($f.Restarts.Count -eq 0 -and $f.Writes -eq 2 -and $f.Marker) 'No restart while a job runs; value written; marker set'
$f.CommandLines = $idle
$r = Invoke-CvMain -Action Install
Assert ($r.Result.Status -eq 'applied' -and $f.Restarts.Count -eq 2 -and -not $f.Marker) 'Later idle run restarts and clears marker'
$r = Invoke-CvMain -Action Install
Assert ($r.Result.Status -eq 'compliant' -and $f.Restarts.Count -eq 2) 'No further restart'
$f = New-Fake -Delegate @($line) -Elevator @($line) -CommandLines @($null)
$f.Marker = $true
Assert ((Invoke-CvMain -Action Install).Result.Status -eq 'restartPending' -and $f.Restarts.Count -eq 0) 'Unreadable command line counts as a running job'

# A job that starts after the first sample still blocks the restart.
$f = New-Fake -Delegate @('TEMP=Z:\Temp') -Elevator @('TEMP=Z:\Temp') -CommandLines $idle
$script:Samples = 0
$script:CvProcesses = { $script:Samples++; $lines = if ($script:Samples -gt 1) { $job } else { $idle }; @($lines | ForEach-Object { [pscustomobject]@{ Name = 'backup-tool.exe'; CommandLine = $_ } }) }
$r = Invoke-CvMain -Action Install
Assert ($r.Result.Status -eq 'restartPending' -and $f.Restarts.Count -eq 0 -and $f.Marker) 'Job is re-checked right before the restart'

# A write that fails after the first one still leaves the restart owed.
$f = New-Fake -Delegate @('TEMP=Z:\Temp') -Elevator @('TEMP=Z:\Temp') -CommandLines $idle
$script:CvWrite = { param($svc, [string[]]$lines) if ($svc -eq 'backup.elevator') { throw 'write failed' }; $script:Fake.Values[$svc] = $lines; $script:Fake.Writes++ }
$threw = $false
try { $null = Invoke-CvMain -Action Install } catch { $threw = $true }
Assert ($threw -and $f.Writes -eq 1 -and $f.Marker) 'Marker is set before the first registry write'

# Uninstall removes only the line.
$f = New-Fake -Delegate @('TEMP=Z:\Temp', $line, 'TMP=Z:\Temp') -Elevator @($line, 'TMP=Z:\Temp') -CommandLines $idle
$r = Invoke-CvMain -Action Uninstall
Assert ($r.Result.Status -eq 'removed' -and (Same $f.Values['backup.delegate'] @('TEMP=Z:\Temp', 'TMP=Z:\Temp')) -and (Same $f.Values['backup.elevator'] @('TMP=Z:\Temp'))) 'Uninstall removes only the line'
Assert ($f.Restarts.Count -eq 2) 'Uninstall restarts once when idle'

# Evidence is read-only and redacts.
$f = New-Fake -Delegate @('TEMP=Z:\Temp', ($secretName + '=' + $tokenValue)) -Elevator @('TEMP=Z:\Temp') -CommandLines $job
$f.Marker = $true
$r = Invoke-CvMain -Action Install -Section Evidence
Assert ($r.ExitCode -eq 0 -and $f.Writes -eq 0 -and $f.Restarts.Count -eq 0 -and $f.Marker) 'Evidence changes nothing'
$json = $r.Result | ConvertTo-Json -Depth 8 -Compress
Assert (-not $json.Contains($tokenValue) -and $json.Contains($secretName + '=[redacted]')) 'Evidence redacts secrets'
Assert ($r.Result.Services[0].Compliant -eq $false -and $r.Result.QemuGuest -and $r.Result.JobRunning) 'Evidence reports compliance, guest and job state'

# Unexpected value type and missing Comet.
$f = New-Fake -Delegate @('TEMP=Z:\Temp') -Elevator @('TEMP=Z:\Temp') -CommandLines $idle
$f.Kinds['backup.elevator'] = 'String'
$r = Invoke-CvMain -Action Install
Assert ($r.ExitCode -eq 1 -and $f.Writes -eq 0) 'Non-multi-string value refused without writing'
$f = New-Fake -Delegate @() -Elevator @() -CommandLines $idle
$script:CvRead = { param($svc) [pscustomobject]@{ Exists = $false; Kind = $null; Lines = @() } }
$r = Invoke-CvMain -Action Install
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'cometNotInstalled' -and $f.Writes -eq 0) 'No Comet services: nothing to do'
Assert ((Invoke-CvMain -Action Install -Section Bogus).ExitCode -eq 1) 'Unknown section refused'
