# windows/packages/component-store-repair: Scan, Repair and InstallMsu. Mocked: no DISM, no task, no files.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/component-store-repair/Invoke-ComponentStoreRepair.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# ---- Static: 5.1 syntax, never restarts ---------------------------------------------------------------------
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$code = (@($tokens | Where-Object { [string]$_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
Assert ($code -notmatch '(?i)Restart-Computer|shutdown|/Restart\b|InitiateSystemShutdown') 'never restarts'
Assert ($code -notmatch '(?i)ResetBase|StartComponentCleanup|Remove-Package|Remove-WindowsPackage') 'never removes packages'
$params = (Get-Command -Name $path).Parameters
foreach ($p in $params.Values) { foreach ($a in $p.Attributes) { if ($a -is [Parameter]) { Assert (-not $a.Mandatory) "$($p.Name) not Mandatory" } } }

# ---- Seams ----------------------------------------------------------------------------------------------------
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Exits = @{}
$script:Saved = [Collections.Generic.List[object]]::new()
$script:Now = [datetime]'2026-11-21T12:00:00'
$script:Busy = $null
$script:Started = $null
$script:Msus = @('C:\msu\windows11.0-kb5043080-x64_aa.msu', 'C:\msu\windows11.0-kb5136489-x64_bb.msu')
$script:Os = [ordered]@{ build = 26100; ubr = 2033; edition = 'ServerStandard'; installationType = 'Server' }
$script:Free = 100GB
$script:Images = @()
$script:Health = 'Healthy'
$script:CsrNow = { $script:Now }
$script:CsrBusy = { $script:Busy }
$script:CsrStartTask = { param($ArgumentLine) $script:Started = $ArgumentLine }
$script:CsrSaveState = { param($State) $script:Saved.Add(($State | ConvertTo-Json -Depth 6 | ConvertFrom-Json)) }
$script:CsrDirExists = { param($p) $p -eq 'C:\msu' }
$script:CsrFileExists = { param($p) $p -like 'D:\sources\install.*' }
$script:CsrListMsu = { param($d) $script:Msus }
$script:CsrOs = { $script:Os }
$script:CsrFreeBytes = { param($p) $script:Free }
$script:CsrFileBytes = { param($p) 4GB }
$script:CsrWimImages = { param($p) $script:Images }
$script:CsrHealth = { param($Op) $script:Calls.Add("health $Op"); $script:Health }
$script:CsrWorkRoot = 'C:\work'
$script:CsrRemoveWork = { $script:Calls.Add('cleanup') }
# expand of an msu yields a wim, an SSU cab and the LCU cab; expand of the LCU cab yields files.
$script:CsrListFiles = { param($d)
    if ($d -match 'kb5136489') { @("$d\SSU-26100.4000-x64.cab", "$d\Windows11.0-KB5136489-x64.cab", "$d\WSUSSCAN.cab", "$d\Windows11.0-KB5136489-x64.wim") } else { @() } }
$script:CsrNative = { param($File, [string[]]$Arguments)
    $line = $File + ' ' + ($Arguments -join ' ')
    $script:Calls.Add($line)
    $rc = 0
    foreach ($k in $script:Exits.Keys) { if ($line -like $k) { $rc = $script:Exits[$k]; break } }
    [pscustomobject]@{ ExitCode = $rc; Tail = @() } }
function Reset { $script:Calls.Clear(); $script:Exits = @{}; $script:Saved.Clear(); $script:Busy = $null; $script:Started = $null; $script:Free = 100GB; $script:Images = @(); $script:Os.build = 26100 }
function M { Invoke-CsrMain -PinVersion '1.0.0' -Action 'Install' @args }

# ---- Launcher: off switch, validation, refusal, start ----------------------------------------------------------
Reset
$r = Invoke-CsrMain -Action Install -Mode Repair -BackupDate '2026-11-21'
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'noPin' -and -not $script:Started) 'empty pin does nothing'
$r = Invoke-CsrMain -PinVersion '1.0.0' -Mode Scan -Action Uninstall
Assert ($r.ExitCode -eq 0 -and -not $script:Started) 'uninstall does nothing'
foreach ($bad in '', 'Report', 'repair;x') { $r = M -Mode $bad; Assert ($r.ExitCode -eq 1 -and -not $script:Started) "bad mode refused: [$bad]" }

foreach ($d in '', 'yes', 'true', '2026-11-13', '2026-11-22', '21/11/2026') {
    $r = M -Mode Repair -BackupDate $d
    Assert ($r.ExitCode -eq 1 -and $r.Result.status -eq 'refused' -and $r.Result.reason -match 'backup' -and -not $script:Started) "repair refused without a recent backup date: [$d]"
}
$r = M -Mode Repair -BackupDate '2026-11-14'
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'started') 'backup 7 days old accepted'
Assert ($script:Started -match '-Worker' -and $script:Started -match '-Mode Repair' -and $script:Started -match '-BackupDate 2026-11-14') "task line: $script:Started"

Reset
$r = M -Mode InstallMsu
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'MsuPath' -and -not $script:Started) 'InstallMsu needs MsuPath'
$r = M -Mode InstallMsu -MsuPath 'C:\nothere'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'missing folder refused'
$r = M -Mode InstallMsu -MsuPath 'msu'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'relative folder refused'
$script:Msus = @()
$r = M -Mode InstallMsu -MsuPath 'C:\msu'
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'msu' -and -not $script:Started) 'empty folder refused'
$script:Msus = @('C:\msu\windows11.0-kb5043080-x64_aa.msu', 'C:\msu\windows11.0-kb5136489-x64_bb.msu')
$r = M -Mode InstallMsu -MsuPath 'C:\msu\'
Assert ($r.ExitCode -eq 0 -and $script:Started -match '-MsuPath "C:\\msu"( |$)') "trailing backslash dropped before the quote: $script:Started"
Reset
$r = M -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.txt'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'WimPath must be a wim or esd'
$r = M -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.wim'
Assert ($r.ExitCode -eq 0 -and $script:Started -match '-WimPath "D:\\sources\\install.wim"') 'wim accepted'

Reset
$script:Busy = 'dism.exe is running'
$r = M -Mode Scan
Assert ($r.ExitCode -eq 1 -and $r.Result.status -eq 'busy' -and -not $script:Started) 'busy refused'

# ---- Worker: Scan --------------------------------------------------------------------------------------------
Reset
$script:Health = 'Repairable'
$s = Invoke-CsrWorker -Mode Scan
Assert ($s.status -eq 'done' -and $s.health -eq 'Repairable' -and $script:Calls -contains 'health ScanHealth') 'scan records the health state'
Assert ($script:Saved.Count -ge 2 -and $script:Saved[0].status -eq 'running' -and $script:Saved[-1].status -eq 'done') 'state saved at start and end'
Assert (-not @($script:Calls | Where-Object { $_ -match 'RestoreHealth|sfc' })) 'scan repairs nothing'

# ---- Worker: Repair --------------------------------------------------------------------------------------------
Reset
$script:Health = 'Healthy'
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
Assert ($s.status -eq 'done' -and $script:Calls[0] -eq 'dism.exe /Online /Cleanup-Image /RestoreHealth') "plain RestoreHealth first: $($script:Calls[0])"
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand|/Source' })) 'no source needed when Windows Update repairs it'
Assert (@($script:Calls | Where-Object { $_ -eq 'sfc.exe /scannow' }).Count -eq 1 -and $s.health -eq 'Healthy') 'sfc then CheckHealth'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth' = -2146498529 }
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
$src = @($script:Calls | Where-Object { $_ -match '/Source:' })
Assert ($src.Count -eq 1 -and $src[0] -match '/LimitAccess$') "first source succeeds, LimitAccess: $($src -join ' | ')"
Assert ($src[0] -match '/Source:WIM:C:\\work\\[^ ]*kb5136489[^ ]*\.wim:1 /LimitAccess$') "inner wim tried first: $($src[0])"
Assert (@($script:Calls | Where-Object { $_ -like 'expand.exe -F:* C:\msu\windows11.0-kb5136489*' }).Count -eq 1) 'msu expanded'
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand.exe .*(SSU-|WSUSSCAN)' })) 'SSU and WSUSSCAN cabs not expanded'
Assert ($s.steps[0].hex -eq '0x800f081f' -and $s.status -eq 'done' -and $script:Calls -contains 'sfc.exe /scannow') 'source failure recorded, then repaired'
Assert ($script:Calls[-1] -eq 'cleanup') 'expanded sources removed'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Images = @(
    [pscustomobject]@{ Index = 1; Version = '10.0.26100.1742'; EditionId = 'ServerStandard'; InstallationType = 'Server Core' },
    [pscustomobject]@{ Index = 2; Version = '10.0.26100.1742'; EditionId = 'ServerStandard'; InstallationType = 'Server' },
    [pscustomobject]@{ Index = 4; Version = '10.0.26100.1742'; EditionId = 'ServerDatacenter'; InstallationType = 'Server' })
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu' -WimPath 'D:\sources\install.wim'
$src = @($script:Calls | Where-Object { $_ -match '/Source:' })
Assert ($src[-1] -match '/Source:WIM:D:\\sources\\install.wim:2 /LimitAccess$') "install.wim index matches build and edition: $($src[-1])"
Assert ($s.status -eq 'failed' -and -not ($script:Calls -contains 'sfc.exe /scannow')) 'all sources fail: failed, no sfc'
Assert ($s.steps.Count -eq 1 + $src.Count) 'one step per attempt'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Images = @([pscustomobject]@{ Index = 1; Version = '10.0.20348.587'; EditionId = 'ServerStandard'; InstallationType = 'Server' })
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.wim'
Assert (-not @($script:Calls | Where-Object { $_ -match '/Source:' }) -and @($s.notes) -match 'no image') 'other build in the wim is not used'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Free = 5GB
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand' }) -and @($s.notes) -match 'free') 'no expansion on a nearly full disk'

Reset
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-10-01'
Assert ($s.status -eq 'refused' -and $script:Calls.Count -eq 0) 'worker checks the backup date again'

# ---- Worker: InstallMsu ----------------------------------------------------------------------------------------
Reset
$script:Exits = @{ 'dism.exe /Online /Add-Package*' = 3010 }
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 1 -and $d[0] -eq 'dism.exe /Online /Add-Package /PackagePath:C:\msu /NoRestart') "24H2: one folder install, checkpoint ordering by DISM: $($d -join ' | ')"
Assert ($s.status -eq 'done' -and $s.restartNeeded -eq $true -and $s.steps[0].exit -eq 3010) '3010 is success, restart needed, not done'

Reset
$script:Os.build = 20348
$script:Exits = @{ '*kb5043080*' = 14081 }
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 1 -and $d[0] -like 'dism.exe /Online /Add-Package /PackagePath:C:\msu\windows11.0-kb5043080*.msu /NoRestart') 'older build: one file at a time, stops at the first failure'
Assert ($s.status -eq 'failed' -and $s.steps[0].hex -eq '0x00003701') 'exit 14081 is 0x3701'

Write-Output 'component-store-repair tests passed'
