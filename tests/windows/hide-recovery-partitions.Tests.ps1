# hide-recovery-partitions module tests. Partitions and removals are faked behind seams; backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/hide-recovery-partitions.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("hide-rp-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

$winreGpt = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
$efiGpt = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$basicDataGpt = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'

function New-Part {
    param(
        [int]$Disk = 0,
        [int]$Part = 1,
        [string]$Letter = '',
        [string]$GptType = $basicDataGpt,
        $MbrType = $null,
        [long]$Size = 536870912,
        [bool]$IsBoot = $false,
        [string]$Guid = ''
    )
    @{
        diskNumber      = $Disk
        partitionNumber = $Part
        driveLetter     = $Letter
        gptType         = $GptType
        mbrType         = $MbrType
        size            = $Size
        isBoot          = $IsBoot
        guid            = $Guid
    }
}

function Reset-Test {
    param($Parts = @())
    $script:FakeParts = [Collections.Generic.List[object]]::new()
    foreach ($p in $Parts) { $script:FakeParts.Add($p) }
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:RemoveThrowOnLetter = ''
    $script:KeepLetterAfterRemove = $false
    $script:ReadThrows = $false
    $script:ReadCount = 0
    $script:OnSecondRead = $null
    $script:RpSystemDrive = 'C:'
    $script:RpBackupDir = Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
}

$script:RpProtectDir = { param($Path) $script:Log.Add('protect') }
$script:RpReadPartitions = {
    if ($script:ReadThrows) { throw 'CIM failure' }
    $script:ReadCount++
    if ($script:ReadCount -eq 2 -and $null -ne $script:OnSecondRead) { & $script:OnSecondRead }
    return @($script:FakeParts.ToArray())
}
$script:RpRemoveLetter = {
    param([int]$DiskNumber, [int]$PartitionNumber, [string]$DriveLetter)
    if ($script:RemoveThrowOnLetter -eq $DriveLetter) { throw "Access denied on $DriveLetter" }
    $script:Log.Add("remove:${DiskNumber}:${PartitionNumber}:${DriveLetter}")
    if (-not $script:KeepLetterAfterRemove) {
        foreach ($p in $script:FakeParts) {
            if ($p.diskNumber -eq $DiskNumber -and $p.partitionNumber -eq $PartitionNumber) {
                $p.driveLetter = ''
            }
        }
    }
}

function Backups { @(if (Test-Path -LiteralPath $script:RpBackupDir) { Get-ChildItem -LiteralPath $script:RpBackupDir -File }) }

# 1. Clean disk (including [char]0 unmounted WinRE, OS C:, normal data D:, >4GiB WinRE, IsBoot WinRE, GPT non-target with mbrType=39): unchanged.
$cleanParts = @(
    (New-Part -Disk 0 -Part 1 -Letter ([string][char]0) -GptType $efiGpt -Size 104857600),
    (New-Part -Disk 0 -Part 2 -Letter 'C' -GptType $basicDataGpt -Size 250000000000 -IsBoot $true),
    (New-Part -Disk 0 -Part 3 -Letter '' -GptType $winreGpt -Size 785580032),
    (New-Part -Disk 0 -Part 4 -Letter 'D' -GptType $basicDataGpt -Size 100000000000),
    (New-Part -Disk 0 -Part 5 -Letter 'E' -GptType $winreGpt -Size 4294967297),
    (New-Part -Disk 0 -Part 6 -Letter 'F' -GptType $winreGpt -Size 536870912 -IsBoot $true),
    (New-Part -Disk 0 -Part 7 -Letter 'G' -GptType $basicDataGpt -MbrType 39 -Size 536870912),
    (New-Part -Disk 0 -Part 8 -Letter 'C' -GptType $winreGpt -Size 536870912)
)
Reset-Test -Parts $cleanParts
$r = Invoke-RpJob
Assert-Same $r.ExitCode 0 'clean exit'
Assert-Same $r.Status 'unchanged' 'clean status'
Assert-Same $script:Log.Count 0 'clean changes nothing'
Assert-Same (@(Backups).Count) 0 'clean writes no backup'
$line = ConvertTo-RpJobLine $r | ConvertFrom-Json
Assert-Same $line.job 'hide-recovery-partitions' 'line job'
Assert-Same (@($line.before).Count) 0 'clean line before empty'

# 2. -ReportOnly with GPT WinRE (D:), GPT EFI (E:), MBR WinRE (F:): drift exit 1, no backup, no remove.
$driftParts = @(
    (New-Part -Disk 0 -Part 1 -Letter 'E' -GptType $efiGpt -Size 104857600),
    (New-Part -Disk 0 -Part 2 -Letter 'C' -GptType $basicDataGpt -Size 250000000000 -IsBoot $true),
    (New-Part -Disk 0 -Part 3 -Letter 'd' -GptType $winreGpt -Size 785580032),
    (New-Part -Disk 1 -Part 2 -Letter 'F' -GptType '' -MbrType 39 -Size 524288000)
)
Reset-Test -Parts $driftParts
$r = Invoke-RpJob -ReportOnly
Assert-Same $r.ExitCode 1 'report-only drift exit'
Assert-Same $r.Status 'drift' 'report-only drift status'
Assert-Same $r.Mode 'report' 'report-only mode'
Assert-Same (@($r.Before).Count) 3 'report-only target count'
Assert-Same $r.Before[0].kind 'gpt-efi' 'first target kind'
Assert-Same $r.Before[1].driveLetter 'D' 'second target normalized upper letter'
Assert-Same $r.Before[1].kind 'gpt-winre' 'second target kind'
Assert-Same $r.Before[2].kind 'mbr-winre' 'third target kind'
Assert-Same $script:Log.Count 0 'report-only touches nothing'
Assert-Same (@(Backups).Count) 0 'report-only writes no backup'

# 3. Real run removes all 3 matched letters after backup + read-back, leaves C: untouched.
Reset-Test -Parts $driftParts
$r = Invoke-RpJob
Assert-Same $r.ExitCode 0 'run exit'
Assert-Same $r.Status 'removed' 'run status'
Assert-Same (@($r.Before).Count) 3 'run before count'
Assert-Same (@($r.After).Count) 0 'run after empty'
Assert-Same ($script:Log -join ',') 'protect,remove:0:1:E,remove:0:3:D,remove:1:2:F' 'protect before ordered removals'
$files = @(Backups)
Assert-Same $files.Count 1 'one backup created'
Assert-Same $r.Backup $files[0].Name 'backup name returned'
$doc = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
Assert-Same (@($doc.targets).Count) 3 'backup targets count'
Assert-Same (@($doc.partitions).Count) 4 'backup holds full partition list'
$cPart = @($script:FakeParts | Where-Object { $_.partitionNumber -eq 2 -and $_.diskNumber -eq 0 })[0]
Assert-Same $cPart.driveLetter 'C' 'OS drive C untouched'
$line = ConvertTo-RpJobLine $r | ConvertFrom-Json
Assert-Same (@($line.before).Count) 3 'line before array count'
Assert-Same (@($line.after).Count) 0 'line after array count'

# 4. Never overwrite existing backup on subsequent run.
$firstContent = Get-Content -LiteralPath $files[0].FullName -Raw
$script:FakeParts[0].driveLetter = 'E'
$script:Log.Clear()
$r2 = Invoke-RpJob
Assert-Same $r2.ExitCode 0 'second run exit'
$files2 = @(Backups)
Assert-Same $files2.Count 2 'second run adds new backup file'
Assert-Same (Get-Content -LiteralPath $files[0].FullName -Raw) $firstContent 'first backup unchanged'

# 5. Fail closed on backup failure: deletes/removes nothing.
$oneTarget = @(
    (New-Part -Disk 0 -Part 2 -Letter 'C' -GptType $basicDataGpt -Size 250000000000 -IsBoot $true),
    (New-Part -Disk 0 -Part 3 -Letter 'D' -GptType $winreGpt -Size 785580032)
)
Reset-Test -Parts $oneTarget
$blocker = Join-Path $tmpRoot 'blocker'
Set-Content -LiteralPath $blocker -Value 'x'
$script:RpBackupDir = $blocker
$r = Invoke-RpJob
Assert-Same $r.ExitCode 2 'backup fail exit'
Assert-Same $r.Status 'failed' 'backup fail status'
Assert-True (-not ($script:Log -match '^remove:')) 'backup fail removes nothing'
Assert-Same $script:FakeParts[1].driveLetter 'D' 'letter preserved on backup fail'

# 6. Snapshot drift between backup and removal aborts with exit 2 and removes nothing.
Reset-Test -Parts $oneTarget
$script:OnSecondRead = { $script:FakeParts[1].driveLetter = 'E' }
$r = Invoke-RpJob
Assert-Same $r.ExitCode 2 'snapshot drift exit'
Assert-Same $r.Status 'failed' 'snapshot drift status'
Assert-True (-not ($script:Log -match '^remove:')) 'snapshot drift removes nothing'
Assert-Same $script:FakeParts[1].driveLetter 'E' 'snapshot drift left E'

# 6b. Partition GUID change between snapshot and removal aborts with exit 2 and removes nothing.
$oneTargetGuid = @(
    (New-Part -Disk 0 -Part 2 -Letter 'C' -GptType $basicDataGpt -Size 250000000000 -IsBoot $true),
    (New-Part -Disk 0 -Part 3 -Letter 'D' -GptType $winreGpt -Size 785580032 -Guid '{11111111-1111-1111-1111-111111111111}')
)
Reset-Test -Parts $oneTargetGuid
$script:OnSecondRead = { $script:FakeParts[1].guid = '{22222222-2222-2222-2222-222222222222}' }
$r = Invoke-RpJob
Assert-Same $r.ExitCode 2 'guid drift exit'
Assert-Same $r.Status 'failed' 'guid drift status'
Assert-True (-not ($script:Log -match '^remove:')) 'guid drift removes nothing'

# 7. Partial failure: RpRemoveLetter throws on second partition -> still populates $r.After with live remaining state.
$twoTargets = @(
    (New-Part -Disk 0 -Part 1 -Letter 'E' -GptType $efiGpt -Size 104857600),
    (New-Part -Disk 0 -Part 2 -Letter 'C' -GptType $basicDataGpt -Size 250000000000 -IsBoot $true),
    (New-Part -Disk 0 -Part 3 -Letter 'D' -GptType $winreGpt -Size 785580032)
)
Reset-Test -Parts $twoTargets
$script:RemoveThrowOnLetter = 'D'
$r = Invoke-RpJob
Assert-Same $r.ExitCode 2 'partial fail exit'
Assert-Same $r.Status 'failed' 'partial fail status'
Assert-True ($r.Error -match 'Access denied on D') 'partial fail captures error'
Assert-Same (@($r.Before).Count) 2 'partial fail before count'
Assert-Same (@($r.After).Count) 1 'partial fail after populated with remaining live target'
Assert-Same $r.After[0].driveLetter 'D' 'partial fail remaining letter is D'

# 8. Letter still present after removal -> exit 2, After populated.
Reset-Test -Parts $oneTarget
$script:KeepLetterAfterRemove = $true
$r = Invoke-RpJob
Assert-Same $r.ExitCode 2 'still present exit'
Assert-Same $r.Status 'failed' 'still present status'
Assert-Same (@($r.After).Count) 1 'still present after count'

# 9. Get-Partition failure -> fail closed exit 2.
Reset-Test -Parts @()
$script:ReadThrows = $true
$r = Invoke-RpJob -ReportOnly
Assert-Same $r.ExitCode 2 'read throw exit'
Assert-Same $r.Status 'failed' 'read throw status'
Assert-True ($r.Error -match 'CIM failure') 'read throw message'

# 10. Single target JSON line keeps before/after as arrays.
Reset-Test -Parts $oneTarget
$r = Invoke-RpJob -ReportOnly
$line1 = ConvertTo-RpJobLine $r | ConvertFrom-Json
Assert-Same (@($line1.before).Count) 1 'single target line before count'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'hide-recovery-partitions tests passed'
