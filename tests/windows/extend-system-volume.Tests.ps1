$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/extend-system-volume/Invoke-ExtendSystemVolume.ps1')

function Assert($ok, $message) { if (-not $ok) { throw $message } }

# A fake disk: C: is partition 4; SizeMax is what Windows would allow after a rescan.
function New-Fake {
    param([uint64]$Size = 80GB, [uint64]$SizeMax = 120GB, [object[]]$Others = @())
    $f = [pscustomobject]@{ Size = $Size; SizeMax = $SizeMax; Others = $Others; Rescans = 0; Resizes = 0 }
    $script:Fake = $f
    $script:EsDriveLetter = { 'C' }
    $script:EsRescan = { $script:Fake.Rescans++ }
    $script:EsPartition = { param($l) [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Offset = [uint64]593494016; Size = $script:Fake.Size } }
    $script:EsDisk = { param($d) [pscustomobject]@{ PartitionStyle = 'GPT'; Size = [uint64]120GB } }
    $script:EsDiskPartitions = {
        param($d)
        @([pscustomobject]@{ PartitionNumber = 1; Offset = [uint64]1MB; Size = [uint64]450MB; Type = 'Recovery' }) +
        @([pscustomobject]@{ PartitionNumber = 4; Offset = [uint64]593494016; Size = $script:Fake.Size; Type = 'Basic' }) + $script:Fake.Others
    }
    $script:EsSupported = { param($l) [pscustomobject]@{ SizeMin = [uint64]40GB; SizeMax = $script:Fake.SizeMax } }
    $script:EsResize = { param($l, $s) $script:Fake.Resizes++; $script:Fake.Size = $s }
    return $f
}

# Off switch and validation.
$f = New-Fake
foreach ($a in @('Install', 'Uninstall')) {
    $r = Invoke-EsMain -Action $a -PinVersion ''
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'disabled') "Empty pin disables $a"
}
$r = Invoke-EsMain -Action Uninstall
Assert ($r.ExitCode -eq 1 -and $f.Resizes -eq 0) 'Uninstall refused, nothing shrunk'
$r = Invoke-EsMain -Action Frob
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -eq 'unsupported action') 'Unknown action refused'
$r = Invoke-EsMain -Action Install -Section Nope
Assert ($r.ExitCode -eq 1) 'Unknown section refused'
Assert ($f.Rescans -eq 0 -and $f.Resizes -eq 0) 'Refusals touch nothing'

# Evidence is read-only: no rescan, no resize.
$f = New-Fake
$r = Invoke-EsMain -Action Install -Section Evidence
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'evidence' -and $f.Rescans -eq 0 -and $f.Resizes -eq 0) 'Evidence changes nothing'
Assert ($r.Result.Before.Gain -eq 40GB -and $r.Result.Before.PartitionsAfter.Count -eq 0) 'Evidence reports the gain and no partition after C:'

# Extend into free space after C:.
$f = New-Fake
$r = Invoke-EsMain -Action Install
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'extended' -and $f.Resizes -eq 1 -and $f.Rescans -eq 1) 'Extends once after a rescan'
Assert ($r.Result.After.Size -eq 120GB) 'Read-back shows the new size'

# Nothing to gain: compliant, no resize.
$f = New-Fake -Size 120GB -SizeMax (120GB + 1MB)
$r = Invoke-EsMain -Action Install
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'compliant' -and $f.Resizes -eq 0) 'Under 16 MiB gain is compliant'

# A partition after C: blocks the extend.
$f = New-Fake -Others @([pscustomobject]@{ PartitionNumber = 5; Offset = [uint64]86GB; Size = [uint64]600MB; Type = 'Recovery' })
$r = Invoke-EsMain -Action Install
Assert ($r.ExitCode -eq 1 -and $f.Resizes -eq 0 -and $r.Result.Before.PartitionsAfter[0].Number -eq 5) 'Partition after C: refuses and is named'

# A resize that does not stick is a failure.
$f = New-Fake
$script:EsResize = { param($l, $s) $script:Fake.Resizes++ }
$r = Invoke-EsMain -Action Install
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like 'read-back*') 'Read-back mismatch fails'

# Output stays one bounded line.
$line = ConvertTo-EsLine $r.Result
Assert ([System.Text.Encoding]::UTF8.GetByteCount($line) -le 2000 -and $line -notmatch "`n") 'One line under 2000 bytes'

# Unvalidated input is clipped, so a refusal stays bounded too.
$r = Invoke-EsMain -Action ('x' * 5000) -Section ('y' * 5000)
$line = ConvertTo-EsLine $r.Result
Assert ($r.ExitCode -eq 1 -and $r.Result.Action.Length -le 40 -and [System.Text.Encoding]::UTF8.GetByteCount($line) -le 2000) 'Long Action/Section clipped'
$big = [ordered]@{ Package = 'extend-system-volume'; Status = 'error'; Other = ('z' * 5000) }
Assert ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-EsLine $big)) -le 2000) 'Final fallback keeps the line bounded'

Write-Output 'extend-system-volume tests passed'
